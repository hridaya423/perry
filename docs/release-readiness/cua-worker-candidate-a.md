# Candidate A: one Cua worker per execution attempt

## Usage (caller's view)

The caller acquires one attempt, passes that attempt through the task, and retires the same value. It never supplies a session string to a later cleanup path.

```swift
let attempt = try await cuaWorkers.acquire(
    owner: .background(taskID),
    resources: [.workspace(workspace.path)]
)
let context = try await attempt.capture(target: targetHint)
try await cuaWorkers.claim(
    [.application(context.target.bundleID.lowercased())],
    for: attempt.id
)
let runtime = SupervisedAgentRuntime(
    planner: selection.runtime,
    workspaceURL: workspace,
    computerUse: attempt,
    remoteIntegrations: integrations
)
let outcome = await runner.run(
    id: taskID,
    runtime: runtime,
    context: context,
    verifier: WorkspaceStepVerifier(baseURL: workspace, cuaWorker: attempt)
)
let stop = await attempt.retire(.outcome(outcome))
try await cuaWorkers.release(attempt.id, after: stop)
```

Foreground Do uses the same sequence with `.foreground`; Guide and dictation each acquire a distinct owner and pass it to `CuaGuideTreeReader` or text insertion. A paused live supervisor keeps its attempt. Approval suspension retires that attempt, and resumption acquires a new one.

## Problem

`AppController` currently owns one `CuaDriverClient` at `App/AppController.swift:138`. That actor owns one process, pipe pair, initialization task, generation, pending requests, and session states, so task, guide, and dictation IDs select state inside one process rather than isolate processes. Health, capture, execution, verification, finalization, erasure, guides, and dictation reach it. `startBackgroundTask` also reserves the three-task slot after setup has created a Cua session. These are current mechanics, not historical intent; the client is uncommitted and its rationale is unknown.

## Shape

`CuaExecutionAttempt` is the deep per-attempt boundary. It owns one `CuaDriverClient`, typed session identity, setup work, target receipt, and retirement state, while hiding session strings and worker selection.

```swift
struct CuaAttemptID: Hashable, Sendable {
    let taskID: TaskID
    let generation: UUID
}

struct CuaSessionID: Hashable, Sendable {
    let rawValue: String
}

enum CuaAttemptState: Sendable, Equatable {
    case reserved
    case starting
    case running
    case retiring
    case retired
}

enum CuaStopResult: Sendable, Equatable {
    case stopped
    case unconfirmed(String)
}

actor CuaExecutionAttempt {
    let id: CuaAttemptID
    let sessionID: CuaSessionID

    func capture(target: CuaTargetHint?) async throws -> CuaCapturedWindow
    func target() async -> CuaWindowTarget?
    func execute(_ action: ComputerAction) async throws -> StepResult
    func verify(_ step: Step) async -> VerificationStatus?
    func insertText(_ text: String, target: CuaTargetHint) async throws -> CuaWindowTarget
    func retire(_ reason: CuaRetirementReason) async -> CuaStopResult
}

actor CuaWorkerCoordinator {
    func acquire(owner: CuaWorkerOwner, resources: Set<BackgroundTaskResource>) async throws -> CuaExecutionAttempt
    func claim(_ resources: Set<BackgroundTaskResource>, for id: CuaAttemptID) async throws
    func release(_ id: CuaAttemptID, after stop: CuaStopResult) async throws
    func stopAll(_ reason: CuaRetirementReason) async -> [CuaStopResult]
}
```

The coordinator owns active leases, three-worker capacity, and application, workspace, and integration conflicts. It is not a multi-worker Cua facade and stores no reusable clients or inventory cache. `acquire` reserves capacity before local process startup; `claim` extends the lease when capture reveals the application. `release` succeeds only after termination is established, so a failed stop keeps the lease occupied.

## Module map

- `App/CuaWorker.swift` owns `CuaWorkerCoordinator`, `CuaExecutionAttempt`, typed leases, and lifecycle state. It contains scheduling policy but no JSON-RPC transport.
- `App/CuaDriverClient.swift` owns the local pinned process, protocol, generation checks, and awaited child termination. `CuaDriverConfiguration.discover` remains the production trust boundary.
- `App/AppController.swift` owns explicit foreground, background, Guide, dictation, health, reload, termination, and erasure owners. It no longer looks up a worker by task ID for cleanup.
- `AccessibilityActionRuntime`, `WorkspaceStepVerifier`, `CuaGuideTreeReader`, and `ExecutionFinalizer` receive the attempt they use; current fixtures remain the test seam.

`CuaDriverClient` remains the local transport and pin/trust boundary. Its `CuaDriverConfiguration.discover` path and `init(configuration:)` seam stay intact. Retirement rejects work, cancels initialization, invalidates the generation, resumes pending waiters, sends process termination, and awaits exit within 500 ms. If stop is unconfirmed, it may escalate and returns `.unconfirmed`; it never sends an unsupported MCP cancellation notification. Late responses remain generation-filtered and cannot replay an uncertain action.

Retirement is the only place that releases the process-backed lease. `CuaExecutionAttempt` checks state and task cancellation around health, capture, runtime selection, and execution. A retired attempt cannot start, restart, or publish a result. Reload, termination, and erasure freeze acquisition, stop all attempts, and wait before reuse. Settings affect future verified factory inputs only.

Automatic cancellation calls `retire` and retains the task record, in-flight marker, target receipt, and context for inspection. Explicit `discard` is a separate user action and may delete them only after the worker is stopped.

The existing `CuaWindowTarget` remains the receipt of exact window identity: bundle ID, process ID, window ID, and connection generation. Resume passes the persisted bundle, process, window, and title as a hint to a new attempt, then records the new worker generation returned by Cua. No caller can silently downgrade this to bundle-only matching.

## Required traces

1. Three unrelated background tasks acquire distinct clients. Retiring A stops only A; B and C continue, while A's in-flight checkpoint and uncertain receipt remain.
2. Cancellation during initialization, capture, runtime selection, or execution retires the attempt before its next side effect, so no late process or result appears.
3. Approval suspension binds cleanup to the old attempt. Resumption creates one new attempt for the persisted step; old cleanup cannot retire it. A paused live supervisor retains its attempt.
4. A fourth task queues before acquiring a client. Application, workspace, and integration claims remain until the old process stops.
5. Timeout, unexpected exit, reload, termination, and erasure stop or invalidate affected attempts before reuse.

## Tests

Use the existing configuration and process-fixture seam to assert distinct clients and generations. Record startup, capture, retirement, process exit, and lease release in order. Cover each setup cancellation boundary, late-response filtering, retired-attempt rejection, A-only stop with B and C active, fourth-task queueing, unconfirmed-stop retention, and one exact-step resume. Keep production-definition tests on `CuaDriverConfiguration.discover` so fixtures cannot bypass pin and trust checks.

## Tradeoffs accepted

- We accept one process startup per logical execution attempt in exchange for cancellation isolation and a direct ownership boundary.
- We accept a bounded active-lease ledger in exchange for keeping capacity and resource policy out of every caller.
- We accept an explicit stop wait and possible escalation in exchange for not releasing a resource while its child may still act.
- We accept a new process after approval resume in exchange for making the old cleanup incapable of touching the resumed run.

## Alternatives considered

One client with stronger session locks still risks B and C when A stops. A task-ID-to-client facade centralizes dispatch but leaks replacement policy into cleanup. Independent caller construction provides isolation but duplicates capacity, resource, and stop policy. Candidate A keeps those policies in one lease owner while each attempt owns its client.

## Synthesis decision

This is the unsynthesized Candidate A package for arena comparison.

## Open questions and risks

- Should an unconfirmed stop block all later acquisitions, or should the UI expose a recovery action that only an operator can resolve?
- Does process termination require a specific TERM-to-KILL interval inside the 500 ms budget on supported macOS versions?
- Should the health owner be long-lived for Settings display or short-lived per probe, given that it must never become an execution worker?

## Next implementation step

Add the typed attempt state and awaited retirement to the existing Cua client seam, wire one foreground Do attempt through `CuaExecutionAttempt`, and prove stop ordering before migrating background, Guide, dictation, reload, termination, and erasure callers.
