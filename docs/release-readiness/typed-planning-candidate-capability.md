# Candidate: provider-carried typed planning capability

## Usage (caller's view)

The background queue asks the real inventory for a typed workspace planner before it acquires desktop context:

```swift
let inventory = try await inventoryInspector.inspect(workingDirectory: workspace)
let typedSelection = selector.select(
    from: inventory.registry,
    preferredProviderID: preferredProviderID,
    requiredPlanning: .workspaceFile
)

if let capability = typedSelection?.typedPlanningCapability,
   let plan = try await capability.workspaceExecutionPlan(
       goal: goal,
       workspace: workspace,
       taskID: taskID
   ) {
    let record = try await coordinator.enqueue(executablePlan: plan)
    try await contextStore.save(
        BackgroundTaskMetadata(
            workspacePath: workspace.path,
            preferredRuntimeID: preferredProviderID,
            runtimeRoutingSummary: typedSelection?.routingSummary
        ),
        for: taskID
    )
    return record
}
```

The typed branch claims only the workspace, creates no target metadata, and never asks Cua for permissions, target resolution, or pixels. During migration, a `nil` result means that the request is outside this capability's file grammar; the caller then selects the normal provider, resolves an exact target, captures context, and uses the legacy planner for a GUI or other contextual request. A thrown malformed typed request ends the attempt and cannot enter that fallback.

The final M1 caller makes the capability mandatory for background execution:

```swift
guard let capability = selection.typedPlanningCapability else {
    throw TypedPlanningUnavailable(providerID: selection.providerID)
}
guard let plan = try await capability.workspaceExecutionPlan(
    goal: goal,
    workspace: workspace,
    taskID: taskID
) else {
    throw TypedPlanningUnsupported(goal: goal)
}
let record = try await coordinator.enqueue(executablePlan: plan)
```

## Problem

`queueBackgroundTask` currently asks `makeRuntime` for a `RuntimeProviderAdapter` and then casts it to `LocalTaskPlannerRuntime`. The cast cannot succeed, so `workspaceExecutionPlan(goal:workspace:taskID:)` is unreachable through production routing. The same queue captures a Cua target and fills target metadata before it knows whether the selected plan is file-only, even though `BackgroundTaskMetadata` already permits all target fields to remain nil. M1 needs a typed planning boundary that preserves registry eligibility and fallback explanations without making legacy `Step` output or a concrete local runtime an execution authority.

## Shape

`PerryRuntimes` carries the capability beside the existing planner and executor, while the adapter remains the legacy `AgentRuntime` view:

```swift
public protocol TypedPlanningCapability: Sendable {
    func workspaceExecutionPlan(
        goal: String,
        workspace: URL,
        taskID: TaskID
    ) async throws -> ExecutionPlan?
}

public enum RuntimePlanningRequirement: String, Codable, Hashable, Sendable {
    case any
    case workspaceFile
}

public struct RuntimeProvider {
    public let typedPlanningCapability: (any TypedPlanningCapability)?
}

public struct RuntimeRouteRequest {
    public let requiredPlanning: RuntimePlanningRequirement
}

public struct RuntimeRouteDecision {
    public var typedPlanningCapability: (any TypedPlanningCapability)? { provider.typedPlanningCapability }
}

struct ProductionRuntimeSelection {
    let typedPlanningCapability: (any TypedPlanningCapability)?
}
```

`RuntimeProvider` initializers default the capability to nil, and `RuntimeProviderRegistry` rejects a provider without it when `requiredPlanning == .workspaceFile`. The existing health, authentication, confinement, preference, priority, latency, and fallback rules still choose the provider. `ProductionRuntimeSelection` copies the optional capability with the decision, so AppController never casts a runtime. Latency updates retain the capability. The legacy `RuntimeProviderAdapter` deliberately does not expose it because typed planning is a separate authority surface.

`LocalTaskPlannerRuntime` conforms using its existing method. Its contract is exact: return nil only when the goal is not a canonical single-file request; throw the existing planning or executable-plan error when the recognized request has malformed syntax, an unsafe path, or oversized contents. A returned plan must carry the requested task ID, the claimed workspace, a validated file transform, and `.workspaceWrite`; the capability does not claim resources, issue approval, write files, or verify them. `TaskCoordinator`, `WorkspaceTaskRunner`, `WorkspaceFileRuntime`, and the existing v5 journal remain the only approval and execution authority.

The queue creates and claims the workspace before invoking the capability, then saves typed metadata with `workspacePath` and route information while leaving target fields nil. If typed planning declines, the queue moves to the contextual branch, performs the existing permission checks, resolves the exact target, claims the application after resolution and before pixels or AX, and invokes the legacy planner. If typed planning throws, the queue releases its unpublished workspace through the existing cleanup path, surfaces the planning error, and performs no capture, legacy planning, enqueue, or metadata save. A plan whose task ID or workspace does not match the request is rejected before enqueue.

## Module map

- `Packages/PerryRuntimes/Sources/PerryRuntimes/TypedPlanningCapability.swift` owns the capability contract; `LocalTaskPlannerRuntime.swift` implements the current file-only provider.
- `RuntimeProviderRegistry.swift` stores the optional capability, filters `.workspaceFile` requests, carries it through route decisions, and preserves it when descriptors are updated.
- `App/RuntimeInventory.swift` attaches the local capability while CLI, direct, and planning-only definitions remain nil; `App/ProductionRuntimeSelector.swift` passes the requirement and projects it into the selection.
- `App/AppController.swift` owns typed-first background orchestration, workspace-only claims, contextual capture fallback, metadata rollback, and the eventual removal of legacy background planning.
- `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift` remains the typed plan persistence, approval, execution, and v5 recovery authority; `App/BackgroundTaskContextStore.swift` needs no schema change.

## Migration

1. Add `TypedPlanningCapability`, `RuntimePlanningRequirement`, provider storage, and decision/selection projection with nil defaults.
2. Register the local planner capability from `RuntimeInventoryInspector`; leave CLI, direct, and planning-only providers without typed execution capability.
3. Refactor `queueBackgroundTask` to try the typed route before permission and target acquisition. Keep the contextual legacy branch only for a typed nil during the transition, and never for a typed error.
4. Add typed capabilities as each provider gains a canonical planner and executor. Then make background selection require `.workspaceFile` or the relevant typed capability for every executable route and delete the legacy background-planning branch.
5. Continue decoding and recovering v1/v2 legacy records through the coordinator, but do not accept newly produced legacy plans as M1 background work. Claude and OpenCode remain planning-only until they have a typed capability and approved execution path.

## Tradeoffs accepted

- We accept an optional provider field during migration in exchange for a direct, typed discovery boundary; the final background path requires it.
- We accept two selector queries for a non-file request in exchange for deciding file-only planning before Cua context acquisition.
- We accept nil target metadata for typed file tasks because the existing persisted schema already models target absence.
- We accept local fallback when a preferred provider lacks typed capability because the existing selector records that rejection and preserves the route explanation.

## Alternatives considered

The concrete cast is rejected because the registry intentionally returns an adapter, and it leaks provider representation into AppController without making the typed planner reachable. A unified `TaskPlanner.plan` result containing either `Plan` or `ExecutionPlan` is rejected because every caller must understand two plan authorities, contextual planning remains entangled with file-only work, and legacy acceptance becomes easy to retain indefinitely. A separate local planner returned by `RuntimeInventoryInspector` is rejected because it duplicates provider selection and bypasses the registry's preference, health, confinement, and fallback explanation.

## Real queue regression tests

Use the actual `AppController.queueBackgroundTask` entry point with isolated task/context storage. The internal inventory loader should build a real `RuntimeInventory` through `RuntimeInventoryInspector` with empty CLI and direct-provider inputs, leaving the real selector and local provider registration in use; it must never inject a selection or runtime. Add Cua permission/capture spies only at their existing boundaries.

- A canonical `create file "report.txt" with "bytes"` request selects the typed capability, persists an executable plan with the exact task ID and bytes, holds the task at approval, stores a valid workspace path with nil target fields, and records no permission or capture event and no file effect.
- A recognized malformed file request fails with its typed planning error, leaves no task or metadata, performs no capture, and proves the legacy planner was not called.
- A non-file request receives typed nil, then uses exact target resolution and contextual planning once; the migration test records the target metadata and legacy plan separately.
- A preferred provider without typed capability is rejected by the typed route with the existing fallback explanation; strict M1 mode returns typed-planning-unavailable without a concrete cast or desktop capture.
- Cancellation during typed planning or metadata persistence leaves no runnable orphan record and retains the existing workspace cleanup and rollback behavior.

## Synthesis decision

Pending comparison with the structurally distinct typed-plan candidate.

## Open questions and risks

Should the transition period permit contextual legacy planning for every typed nil, or should a caller classify non-file work before selection so the strict route can begin sooner? The final M1 gate is clear either way: a new background task cannot be published from a legacy `Plan`.

## Next implementation step

Add the capability and requirement fields, register the local planner, then move the typed attempt ahead of Cua permission and capture in the real queue path.
