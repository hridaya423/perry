# Scoped Cua workers

Status: selected implementation contract for M1–M3. No worker-isolation or termination gate is complete merely because this design is selected.

## Problem

The pinned direct Cua protocol cannot cancel one request, and Perry currently shares one process across unrelated work. Each execution attempt needs an independently stoppable process. Acquisition must also own setup: moving only the execution calls would leave health, capture, and planning outside cancellation and capacity limits. [Grounding](cua-worker-grounding.md) records the current call paths and historical-source gaps.

## Usage

Callers scope the entire attempt, including capture, runtime selection, and planning. Workspace paths can be computed before admission, but workspace creation occurs inside the scope. Existing task records are checked before admission and again before execution. Capacity rejection leaves a persisted queued task queued.

```swift
let outcome = try await workers.withWorker(
    scope: .background,
    resources: [.workspace(workspace.path)]
) { worker in
    let context = await self.currentScreenContext(worker: worker, targetHint: targetHint)
    let selection = try await self.selectRuntime(in: workspace, preferred: preferredRuntimeID)
    let plan = try await selection.runtime.plan(goal: goal, context: context)
    try await worker.claimResources(self.resources(for: plan, workspace: workspace))
    return await self.runBackgroundPlan(plan, context: context, worker: worker)
}
```

The usage expresses the lifetime contract; these orchestration signatures are migration targets, not existing APIs. currentScreenContext calls worker.capture, whose service-owned implementation resolves the exact target and claims its application before requesting pixels. The caller does not perform a raw capture followed by a claim. Main-actor orchestration stays in explicitly isolated methods. The service retains and cancels its operation task, rather than relying on every suspension point to remember a launch-generation check.

For an active background cancellation, the owner persists cancellation intent through ResumableTaskRunner before retiring its exact worker handle. An inactive task uses TaskCoordinator.finishCancellation, which retains reconciliation-required records. Explicit deletion remains a separate command. A paused live supervisor stays inside its worker scope; approval suspension ends the scope and resumption acquires a new handle for the exact stored step.

```swift
try await runner.cancel(id: taskID)
try await worker.retire()
```

Maintenance holds admission closed for its whole operation, including artifact deletion. Application termination closes it permanently.

```swift
try await workers.withWorkersStopped {
    await self.performDataErasureAfterWorkersStopped()
}
try await workers.reloadConfiguration()
try await workers.shutdown()
```

## Shape

The service owns a private record for each allocation. A handle is a capability for one immutable allocation, not a lookup by reusable task ID. Its initializer and allocation ID are private to the worker module. Copies refer to the same allocation; retirement cannot affect a replacement handle. No caller receives a Process, pipe, wire session ID, or resource-release method.

```swift
enum CuaWorkerScope: Hashable, Sendable {
    case background
    case foreground
    case guide
    case dictation
    case health
}

struct CuaWorkerHandle: Sendable {
    func capture(target: CuaTargetHint?) async throws -> CuaCapturedWindow
    func claimResources(_ resources: Set<BackgroundTaskResource>) async throws
    func execute(_ action: ComputerAction) async throws -> StepResult
    func verify(_ step: Step) async -> VerificationStatus
    func insertText(_ text: String, target: CuaTargetHint) async throws -> CuaWindowTarget
    func retire() async throws
}

actor CuaWorkerService {
    func withWorker<Value: Sendable>(
        scope: CuaWorkerScope,
        resources: Set<BackgroundTaskResource>,
        operation: @escaping @Sendable (CuaWorkerHandle) async throws -> Value
    ) async throws -> Value
    func withWorkersStopped<Value: Sendable>(
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value
    func health() async -> CuaDriverHealth
    func reloadConfiguration() async throws
    func shutdown() async throws
}
```

Reuse the current resource identity cases during migration rather than introduce a second resource vocabulary. Application IDs and integration IDs are normalized at their existing parsing boundary; workspace paths use the existing validated workspace identity. BackgroundTaskResource gains Sendable conformance when it crosses the actor boundary. Its background-specific name can change with the execution-owner extraction, rather than forcing a separate naming migration here.

The private record owns the concrete client, one wire session, operation cancellation/completion, and claims. Its state progresses through reserved, starting, active, retiring, and stopped. A failed stop remains retiring and keeps its claims. Only the service can remove the record, after it observes both child termination and operation completion. No public stop receipt can authorize release, so a forged success enum cannot unlock resources.

The concrete client remains the pinned JSON-RPC and exact-target boundary. The existing configuration injection seam creates real controlled driver processes in tests. Do not add a second driver protocol solely to replace those process tests with mocks.

## Admission and claims

The service has accepting, maintenance, and permanently closed admission states. It changes state before any await. Worker registration and capacity reservation occur in the same actor turn, before process launch or operation invocation. Cancellation before registration is checked before either occurs; cancellation afterward addresses the registered allocation.

There are three background slots and one slot each for foreground, guide, dictation, and health. These are separate budgets, not seven interchangeable background slots. Demo flows use the guide or foreground scope for their corresponding beat. A rejected scope does not invoke its operation or create a process.

Capture must resolve and validate the exact target, claim its application, and only then request pixels or accessibility state. Move target resolution behind a concrete client method if needed; do not capture first and claim afterward. Retargeting retains previous claims until the scope ends, avoiding release while an earlier effect may still be outstanding.

Planning can reveal integration resources that were unknown at admission. claimResources extends the same allocation's claims atomically before execution. A conflict fails the attempt before that effect is dispatched; withWorker owns cleanup even when claiming throws. The runtime execution boundary must require claims for the typed resource it is about to mutate, rather than trust a plan's summary text. Keep the existing conservative application/workspace/integration serialization until an operation explicitly supports safe overlap.

## Cancellation and maintenance ordering

withWorker owns an operation task from admission through setup and execution. Its cancellation handler retires the same allocation. Normal return and thrown errors also retire it. Retirement first closes that allocation to new calls and cancels its operation and initialization; it does not wait for an end_session RPC behind a blocked request.

Process-retirement completion and operation completion are distinct. A handle's retire call waits for process retirement but never joins its own operation task. The scope owner joins the operation separately before releasing the allocation. Maintenance joins operations from outside their worker scopes; an operation-context tag rejects a maintenance call from inside a worker rather than letting that worker await itself. Both completion paths are bounded; an operation that does not acknowledge cancellation keeps its claims and prevents maintenance from entering its closure.

The process adapter closes its input, signals its owned process and any verified owned process group, and observes exit against a monotonic deadline. Reserve 200 ms for graceful termination, then escalate within the remaining 500 ms total budget. A process or child that cannot be confirmed stopped produces an error and retains the allocation's claims. Do not release resources, reopen a retired client, or report an effect as undone on that error. No unsupported MCP cancellation notification is sent.

Unexpected process exit and timeout retire the allocation. Existing reader/request generation checks remain; the worker's immutable allocation distinguishes separate clients whose local counters both start at zero. A retired handle never reaches an implicit ensureStarted path. A new attempt gets a new client and allocation.

withWorkersStopped closes admission, cancels all registered operations, and retires their workers before entering the maintenance closure. If stopping fails, the closure does not run and admission stays closed. On exit from maintenance, invalidate cached configuration before accepting future work. reloadConfiguration uses the same exclusion rule. shutdown never reopens admission. New acquisitions cannot appear between a stop-all snapshot and deletion.

Persisted cancellation intent precedes the stop request. Automatic completion preserves an in-flight checkpoint and its metadata; an acknowledged process exit does not establish the outcome of a dispatched action. Worker termination must precede releasing resources or completing explicit deletion. Duplicate callbacks address the same allocation and cannot remove another attempt's ownership.

## Module changes

- CuaWorkerService.swift owns admission, allocation handles, resource claims, operation lifetime, and retirement. It owns no planner or provider-selection policy.
- CuaDriverClient.swift owns protocol IO, target resolution/capture, generation checks, and terminal, awaited process retirement. Keep its verified configuration discovery and controlled-process test seam.
- AccessibilityActionRuntime, WorkspaceStepVerifier, CuaGuideTreeReader, and focused text insertion consume the handle. Finalization executes within the scope or after confirmed retirement; it no longer ends a session by string lookup.
- AppController's foreground, background, guide, dictation, health, reload, termination, and erasure paths migrate as complete lifetimes. Pending setup must remain owned and cancellable, including before a durable plan exists. Remove superseded maps/gates only after their replacement paths are tested.

## Synthesis decision

Use [B](cua-worker-candidate-b.md) as the base because its scoped operation owns cleanup after errors and cancellation. The independent judge preferred B, scoring A 7/10 and B 9/10. The main review agrees on the base but treats both as incomplete contracts: neither supplied an admission barrier or complete claims for resources discovered during planning.

Graft [A](cua-worker-candidate-a.md)'s immutable attempt identity and dynamic claims into B. Reject A's public retire-then-release sequence because a caller can leak cleanup or submit a forged stopped result. Remove B's exposed nested session identity and duplicate service/handle retirement APIs. Add service-owned admission exclusion, retained setup tasks, fixed auxiliary budgets, exact-target claims before capture, and process-exit observation before release. No candidate is accepted as implementation or performance evidence.

## Tradeoffs and verification

One process per active scope costs startup and memory, but it makes independent cancellation possible with the pinned protocol. Conservative application locks limit same-app concurrency until safe overlap is supported. A failed stop holds capacity rather than pretending that a resource is safe to reuse.

Implement terminal client retirement first against a driver fixture that ignores TERM. Prove bounded exit, cancellation during initialization, no restart through an old handle, and that a separate client continues. Then implement the service and exercise three real fixture processes, fourth-slot rejection before startup, dynamic-claim conflict, cancellation during setup, old-handle reuse, and admission closed across maintenance. Tests must observe process identity/exit and actual JSON-RPC traffic, not only calls to a mocked stop function.

Migrate production consumers only after those boundaries pass. The final suite must trace paused approval, cancellation after dispatch, record/metadata retention, reload, erasure, and relaunch. Live target-app actions, TCC, 500 ms device measurements, and clean-checkout reproduction remain independent release requirements.
