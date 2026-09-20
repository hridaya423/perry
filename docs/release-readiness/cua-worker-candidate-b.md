# Direction B: Cua-boundary worker isolation

## Usage (caller's view)

`AppController` owns one `CuaWorkerService`. A caller opens a typed scope around the whole setup and run; the scope owns capacity, cancellation, and retirement. The caller never sees `Process`, a wire session string, or an `endSession` lookup.

```swift
let outcome = try await cuaWorkers.withWorker(
    CuaWorkerRequest(
        scope: .background,
        resources: [.application(bundleID), .workspace(workspace)],
        targetHint: metadata.targetHint
    )
) { worker in
    let context = try await worker.capture()
    let route = try await runtimeRoutes.select(for: context, preferred: preferredRuntimeID)
    let runtime = SupervisedAgentRuntime(
        planner: route.runtime,
        workspaceURL: workspace,
        computerUse: worker,
        remoteIntegrations: integrations
    )
    return await runner.run(
        id: taskID,
        runtime: runtime,
        context: context,
        verifier: WorkspaceStepVerifier(baseURL: workspace, worker: worker),
        approvedStepID: approvedStepID
    )
}
```

Foreground `beginDo` keeps its handle while paused or running. Guide, dictation, demo, health, and background resume acquire separate scopes; resume uses the persisted target hint and approval step with a new handle.

```swift
let foregroundOutcome = try await cuaWorkers.withWorker(
    CuaWorkerRequest(scope: .foreground, resources: [.workspace(workspace)], targetHint: currentTarget)
) { worker in
    let context = try await worker.capture()
    return await supervisor.run(runtime: runtime(using: worker), context: context)
}

let resumedOutcome = try await cuaWorkers.withWorker(
    CuaWorkerRequest(scope: .background, resources: resources, targetHint: persistedTarget)
) { worker in
    await runner.run(id: taskID, runtime: runtime(using: worker), approvedStepID: persistedStepID)
}
```

## Problem

`AppController.cuaDriver` at `App/AppController.swift:138` owns one process, pipe pair, initialization task, pending-request table, and connection-generation sequence for foreground execution, background tasks, guides, dictation, and health probes. Session IDs partition state inside that actor, but pinned direct MCP is serial and has no request cancellation, so stopping one session cannot stop only its effect. Setup also runs before `startBackgroundTask` reserves worker and resource capacity. The client is uncommitted salvage and history has no Cua rationale, so this candidate follows the explicit contract and the traces in [cua-worker-grounding](cua-worker-grounding.md) and [cua-request-cancellation](cua-request-cancellation.md).

## Shape

The service owns one `CuaDriverClient` per live worker. A worker identity combines an opaque allocation ID with the client connection generation. The nested session handle keeps the private wire-session value, so callers use only the generation-bound worker handle.

`CuaWindowTarget` remains the exact target receipt: bundle ID, process ID, window ID, and connection generation travel with every capture and verification result.

```swift
struct CuaWorkerIdentity: Hashable, Sendable {
    let allocationID: UUID
    let connectionGeneration: UInt64
}

struct CuaSessionHandle: Hashable, Sendable {
    let worker: CuaWorkerIdentity
    private let wireSessionID: String
}

enum CuaWorkerScope: Sendable {
    case foreground, background, guide, dictation, health
}

enum CuaWorkerResource: Hashable, Sendable {
    case application(String), workspace(URL), integration(String)
}

struct CuaWorkerRequest: Sendable {
    let scope: CuaWorkerScope
    let resources: Set<CuaWorkerResource>
    let targetHint: CuaTargetHint?
}

enum CuaWorkerError: Error {
    case capacityUnavailable
    case retired
    case terminationUnestablished
}

struct CuaWorkerHandle: Sendable {
    var identity: CuaWorkerIdentity { get }
    var session: CuaSessionHandle { get }
    func capture(target: CuaTargetHint? = nil) async throws -> CuaCapturedWindow
    func execute(_ action: ComputerAction) async throws -> StepResult
    func verify(_ step: Step) async -> VerificationStatus?
    func retire(_ reason: CuaRetirementReason) async -> CuaRetirementResult
}

actor CuaWorkerService {
    init(configuration: CuaDriverConfiguration, maximumBackgroundWorkers: Int = 3)
    func withWorker<Result: Sendable>(
        _ request: CuaWorkerRequest,
        operation: @escaping @Sendable (CuaWorkerHandle) async throws -> Result
    ) async throws -> Result
    func health() async -> CuaDriverHealth
    func retire(_ handle: CuaWorkerHandle, reason: CuaRetirementReason) async -> CuaRetirementResult
    func retireAll(_ reason: CuaRetirementReason) async -> [CuaRetirementResult]
}
```

`withWorker` reserves three-background capacity and application, workspace, and integration resources before starting a client or doing health, capture, planning, or runtime selection. Its cancellation handler retires the exact handle. Retirement is idempotent `active → retiring → stopped`: it rejects work, cancels initialization and local waiters, closes pipes, stops the process, and waits for established termination within 500 ms. If termination is not established, it reports failure, keeps the lease, and prevents reuse or restart. No MCP cancellation notification is added; existing request ID and generation checks ignore late responses.

Records are keyed by `CuaWorkerIdentity`, never by `TaskID` or a session string. A retired identity cannot call `ensureStarted`; a new attempt gets a new allocation and generation. Automatic cancellation lets `TaskCoordinator` retain an in-flight uncertain action. Only explicit `discardBackgroundTask` deletes record, workspace, and metadata after no worker remains.

`CuaDriverConfiguration.discover()` remains the pin and trust boundary. Production constructs the service from that validated configuration, so workers cannot select an arbitrary executable or manifest. The existing `CuaDriverClient(configuration:)` seam remains for focused tests; the service adds only a per-allocation factory seam, and `CuaDriverClient` gains an awaited stop result without exposing `Process`.

Runtime selection remains `RuntimeInventoryInspector`, `ProductionRuntimeSelector`, and `RuntimeProviderRegistry`. The selected route enters the scope once, preserving Codex, Claude, OpenCode, direct API, custom, and local behavior while preventing settings refresh from authorizing a different route mid-run.

## Required traces

1. Three unrelated background scopes receive distinct workers. Retiring A stops only A; B and C progress, while A's uncertain checkpoint remains durable.
2. Cancellation during startup, capture, route selection, or execution reaches the scope handler. Retirement blocks late launch and replay.
3. A paused live supervisor keeps its scope. Approval suspension retires it; resume creates a new generation for the persisted step, so old cleanup cannot retire the resumed worker.
4. A fourth request fails capacity before setup and stays queued. Conflicting resources release only after the old worker's stop is established.
5. Timeout, exit, reload, termination, and erasure use handle-specific or `retireAll` paths before reuse. An unestablished stop is reported and held.

## Module map

- `App/CuaWorkerService.swift` owns worker records, typed handles, capacity, leases, cancellation, and retirement.
- `App/CuaDriverClient.swift` remains the per-worker JSON-RPC client, generation guard, trust-boundary consumer, and awaited stop adapter.
- `App/AppController.swift` owns one service and orchestration only; all Cua flows use scopes instead of raw clients or session IDs.
- `AccessibilityActionRuntime`, `WorkspaceStepVerifier`, `CuaGuideTreeReader`, and finalization use the handle. `App/RuntimeSetup.swift` owns the moved setup types and no Cua process.

## Tests

Test the service boundary with an injected per-worker factory and controllable process fixture. Prove distinct workers, A-only retirement, durable uncertainty, cancellation without late launch or replay, old-handle rejection on resume, fourth-request rejection before setup, and lease release only after established stop. Exercise `retireAll` for timeout, exit, reload, termination, erasure, and held-lease failure. Keep existing `CuaDriverClient(configuration:)` generation tests and add validated-configuration trust cases; do not claim live stop success until the fixture exists.

## Synthesis decision

This Direction B candidate puts isolation at the Cua process owner, the smallest boundary that can satisfy independent stop, generation checks, and lease ordering without exposing process mechanics to callers.

## Tradeoffs accepted

- We accept one service actor and one client per worker for process isolation.
- We accept capacity failure before setup for no fourth process or reservation race.
- We accept held resources when stop is unestablished for truthful non-reuse.
- We accept a fresh resume generation for no replay or old-worker cleanup.
- We accept waiter cancellation plus OS stop for protocol correctness without MCP cancellation.

## Alternatives considered

An AppController dictionary of `TaskID` to raw `CuaDriverClient` exposes lifecycle and process ownership, and old cleanup can find a replacement by task ID. It fails the exact-handle requirement.

Keeping one client with many session IDs is the current shape. It hides allocation cost, but serial protocol and shared process still spread cancellation or exit across sessions. It cannot satisfy the first trace.

## Open questions and risks

- Should the process adapter escalate after its first stop request, or report a held lease for recovery?
- Should guide, dictation, and health share background capacity or reserve capacity?
- Should reload and erasure surface all unestablished stops before artifact deletion?

## Next implementation step

Add the service and typed handles with a fakeable per-worker factory, then migrate the foreground scope and its verifier before moving background setup and resume under the same ownership boundary.
