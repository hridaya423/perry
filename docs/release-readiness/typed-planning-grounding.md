# Production typed planning

## Observed failure

`AppController.queueBackgroundTask` asks `makeRuntime` for a production selection, then casts `selection.runtime` to `LocalTaskPlannerRuntime`. `RuntimeRouteDecision.runtime` always returns `RuntimeProviderAdapter`, so that cast cannot succeed. The typed file planner is unreachable through this entry point. Existing multi-action app tests seed persisted typed records and bypass task creation.

`TaskPlanner.plan` returns the legacy `Plan`. `RuntimeProvider` stores that planner and an optional executor; its adapter enforces declared planning and execution operations. `ProductionRuntimeSelector` requests bounded confinement and healthy providers, preserving preference and fallback explanations. `RuntimeInventoryInspector` registers the local planner through the same provider boundary as other planners.

The local planner already offers `workspaceExecutionPlan(goal:workspace:taskID:)`. It produces a canonical typed file-creation action for one explicit supported request, returns nil for non-file requests, and throws for malformed file requests. A thrown typed-planning error must never trigger a legacy or delegated fallback. This function does not provide multi-action planning.

## Current creation flow

The app requests notification permission and probes Accessibility and Screen Recording before selecting a runtime. Inside a background worker it creates a workspace, claims that resource, captures a Cua target, and selects a runtime. It then plans, enqueues the task, saves metadata, and starts the task. This queue path always supplies a captured app and window, but `BackgroundTaskMetadata` already permits nil target fields. File-only metadata does not require a new persistence schema.

The replacement must preserve registry eligibility, per-task preference, cancellation, workspace ownership, task identity, and metadata rollback. It must remove the concrete-type cast. File-only plans should not require a screenshot or desktop-control permission merely to create a plan. GUI planning must retain exact-target capture and its permission checks.

The coordinator executes only typed workspace file creation today. Other canonical operation families must not be presented as executable background work until their executors and verification paths exist. Planner support and executor support are separate facts.

## Existing rationale and limits

The runtime inventory decision and history are recorded in `runtime-inventory/synthesis.md` and `runtime-inventory/history.md`. They preserve one registry, fresh inspection, official authentication, exact executable identity, and bounded execution. The history distinguishes documented product constraints from inferred reasons and records unavailable external evidence. The inventory, selector, and registry remain uncommitted files; a fresh `git log` inspection supplies no history for those files. Their current behavior is evidence of the defect, not evidence of its author's intent.

## Required traces

1. Select the local provider through the real inventory and selector, queue a canonical file request, persist a typed plan, obtain action approval, execute, and verify the file and history.
2. Reject malformed canonical file input without calling legacy planning or creating a side effect.
3. Select a planning-only provider without granting it execution authority or losing the selected-provider explanation.
4. Queue file-only work without requesting capture; require a usable exact target for GUI work.
5. Cancel during planning or metadata persistence without leaving runnable orphan work.
6. Preserve the current two-action receipt, approval, cancellation, and recovery behavior while replacing task creation.

## Design comparison

Compare two structurally distinct shapes before implementation: an explicit optional typed-planning capability carried by the selected provider, and a unified planning result that distinguishes typed execution plans from legacy plans during migration. Neither candidate may convert arbitrary legacy steps into trusted actions, expose concrete provider classes to the app, or claim that the temporary legacy path satisfies M1's final typed-action contract.

Judge each shape on production reachability, ownership of planning versus execution authority, context acquisition without needless capture, failure and cancellation behavior, and the number of concepts the caller must coordinate. Verification must cover the real creation path rather than only a planner method or seeded coordinator records.

## Regression-test boundary

The debug app initializer currently accepts storage and a task coordinator, but no inventory, permission, or capture dependencies. Existing inventory and selector tests stop below `queueBackgroundTask`; lifecycle tests seed records. An injected inventory loader should return a `RuntimeInventory` constructed by the real `RuntimeInventoryInspector` with no CLI definitions or direct credentials. `makeRuntime` must still invoke `ProductionRuntimeSelector`; injecting a preselected runtime would bypass the defect under test.

For a canonical file request, permission and capture spies should fail if called. The queue must persist an approval-held executable plan, the selected provider's routing explanation, a workspace matching the action, and nil target metadata. Then approval and execution must produce the expected file and report. The test must never call `debugSeedBackgroundTask` for this journey.

## Compatibility constraints

`AgentRuntime` currently inherits `TaskPlanner`, and foreground execution, `DoSupervisor`, and runtime tests call `plan(goal:context:)` without a task ID or workspace. A replacement must explicitly preserve that legacy interface during migration. It cannot manufacture a workspace or task identity to satisfy a new signature, nor convert typed actions back into legacy steps. The new queue path must use the canonical planning boundary even while old callers remain on the legacy interface.

`ProductionRuntimeSelection` is constructed only by `ProductionRuntimeSelector`, so it can retain the selected provider rather than copy another planner capability through multiple projections. `RuntimeProviderRegistry.recordLatency` reconstructs providers; any added planning interface must survive that reconstruction. `WorkspaceFileRuntime` requires the exact normalized workspace root, not merely a descendant path, so request binding must use the same rule before a file plan reaches admission.
