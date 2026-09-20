# Candidate: completed receipt prefix with one current action

## Usage (caller's view)

The caller sees the current action through `TaskRecord` and gives the coordinator the captured revision. It never edits a journal, reuses a grant, or turns a nonterminal approval wait into a `DoOutcome`.

```swift
guard let visible = await coordinator.record(id: taskID),
      visible.workspaceActionToApprove != nil else { return }

let prepared = try await coordinator.approveWorkspaceAction(
    id: taskID,
    expectedRevision: visible.revision
)
let progress = try await runner.runWorkspaceTask(
    record: prepared,
    runtime: workspaceRuntime,
    history: transcriptStore,
    startedAt: startedAt
)

switch progress {
case .awaitingApproval(let next):
    presentApproval(for: next)
case .completed(let outcome):
    showCompleted(outcome)
}
```

After action A is verified, the same call returns `.awaitingApproval` with action B. The AppController refreshes from the returned record, so the approval sheet binds B's action ID and revision without inspecting the receipt prefix.

```swift
let cancelled = try await coordinator.requestCancellation(id: taskID)
guard !cancelled.requiresReconciliation else { return }
_ = try await runner.reportWorkspaceTask(
    record: cancelled,
    outcome: .stopped,
    history: transcriptStore,
    startedAt: startedAt
)
```

This is the cancel-after-A path. It writes a stopped transcript containing A's receipt-backed work and removes the task only after that write succeeds. If the current action was dispatched, `requiresReconciliation` stays true and the record is retained instead of being reported or replayed.

On relaunch, the background route does the same revision-bound call for the saved current record. A prepared current action may execute; an awaiting current action is shown for approval; a dispatched current action is report-blocked until reconciliation. A record with a full receipt prefix and no current action is report-only and retries history without recreating a worker or workspace.

## Problem

`TaskCoordinator` currently persists one optional `WorkspaceActionJournal` with `.prepared`, `.dispatched`, or `.verified` for the one action that the typed runner accepts. `ResumableTaskRunner.runWorkspaceTask` rejects plans with more than one action, while `WorkspaceFileRuntime.execute` already creates and verifies one typed file action at a time. Extending this path must retain the canonical `ExecutionPlan`, UUID revision checks, action-scoped approval, dispatch-before-effect ordering, and v1/v2 legacy recovery without allowing a later approval to overwrite earlier evidence. The current `TranscriptStore.append` is idempotent by entry ID, but the task record must remain durable until the report succeeds.

## Shape

The journal becomes one validated value with an append-only completed prefix and at most one mutable current action. The plan remains in `TaskRecord.plan` as `TaskPlan.executable(ExecutionPlan)`; the journal stores only the plan identity, digest, completed evidence, and current authority state.

```swift
public struct WorkspaceActionJournal: Codable, Sendable {
    public let planID: UUID
    public let planDigest: String
    public let completed: [CompletedReceipt]
    public let current: CurrentAction?
}

public struct CompletedReceipt: Codable, Equatable, Sendable {
    public let attemptID: UUID
    public let grantID: UUID
    public let actionIndex: Int
    public let actionID: ActionID
    public let receipt: WorkspaceFileExecutionReceipt
}

public struct ActionReference: Codable, Equatable, Sendable {
    public let actionIndex: Int
    public let actionID: ActionID
}

public enum CurrentAction: Codable, Sendable {
    case awaitingApproval(ActionReference)
    case prepared(WorkspaceActionAttempt)
    case dispatched(WorkspaceActionAttempt)
}

public struct WorkspaceActionAttempt: Codable, Equatable, Sendable {
    public let id: UUID
    public let actionIndex: Int
    public let actionID: ActionID
    public let grant: ExecutionApprovalGrant
}

public enum WorkspaceTaskProgress: Sendable {
    case awaitingApproval(TaskRecord)
    case completed(DoOutcome)
}
```

`CompletedReceipt` retains attempt and grant IDs for correlation, but not the grant itself. A completed receipt is evidence, never an authority. Only a prepared or dispatched `WorkspaceActionAttempt` can be restored into `ExecutionApprovalRegistry`, and restoration still requires a current, non-cancelled record.

The coordinator owns these transitions:

```swift
public func approveWorkspaceAction(id: TaskID, expectedRevision: UUID) async throws -> TaskRecord
public func beginWorkspaceDispatch(id: TaskID, expectedRevision: UUID) throws -> TaskRecord
public func executeWorkspaceAction(
    id: TaskID,
    expectedRevision: UUID,
    runtime: WorkspaceFileRuntime
) async throws -> TaskRecord
public func finishWorkspaceReport(
    id: TaskID,
    expectedRevision: UUID,
    outcome: TranscriptEntry.Outcome
) throws -> DoOutcome
```

`approveWorkspaceAction` resolves the action at `completed.count`, issues a fresh action-scoped grant, rechecks the captured revision, and persists `.prepared`. `beginWorkspaceDispatch` persists `.dispatched` and the in-flight action before `WorkspaceFileRuntime.execute` is called. `executeWorkspaceAction` validates the returned receipt against the plan ID, canonical digest, action ID, action index, requested path, and byte count, then appends the receipt and advances the current state in one coordinator mutation. If another action remains, it creates `.awaitingApproval` for that exact next action. If the prefix is complete, `current` becomes `nil` and the record enters report-only state. A returned receipt that cannot be durably appended leaves the current action dispatched and uncertain.

`ResumableTaskRunner` keeps the existing worker boundary but runs one current action per call:

```swift
public func runWorkspaceTask(
    record: TaskRecord,
    runtime: WorkspaceFileRuntime,
    history: TranscriptStore,
    startedAt: Date
) async throws -> WorkspaceTaskProgress

public func reportWorkspaceTask(
    record: TaskRecord,
    outcome: TranscriptEntry.Outcome,
    history: TranscriptStore,
    startedAt: Date
) async throws -> DoOutcome
```

The runner returns `.awaitingApproval` after a successful non-final action and never appends completion history at that boundary. On the final verified action it appends a completed transcript before calling `finishWorkspaceReport`. The explicit report method handles a cancelled partial prefix and retries a failed history write without execution. It accepts `.stopped` for a cancellation with no uncertain current action and accepts `.completed` only for a full prefix with no current action. It rejects a completed or stopped report when a dispatched action remains uncertain.

The prefix is the canonical checkpoint for executable records. The existing `TaskCheckpoint` remains in the task envelope for legacy decoding and UI projections, but the coordinator derives and validates it from the journal: `nextStepIndex == completed.count`, `inFlightStepID` is present only for `.dispatched`, and `suspendedStepID` names only `.awaitingApproval`. No caller can advance the checkpoint independently. The initial typed record contains an awaiting current action for index zero; after A, the persisted shape is:

| State | Completed prefix | Current action | Effect allowed |
| --- | --- | --- | --- |
| Initial approval | empty | awaiting A | no |
| A prepared | empty | prepared A | no |
| A dispatched | empty | dispatched A | one in-flight attempt, uncertain on interruption |
| A verified | A receipt | awaiting B | no |
| B prepared | A receipt | prepared B | no |
| B dispatched | A receipt | dispatched B | one in-flight attempt, uncertain on interruption |
| All verified | A and B receipts | none | no; report only |

The journal validator runs when decoding and before each replacement. It requires `planID` and `planDigest` to match `ExecutionPlan`, indexes to equal the contiguous range `0..<completed.count`, action IDs to match those plan positions, and every receipt to match its action's typed postcondition. It rejects gaps, duplicate action IDs, out-of-order receipts, mismatched digests, a current action that is not the next prefix index, and a current grant whose task, plan, digest, or action scope differs. A duplicate completion callback fails the expected revision or current attempt check after the first append, so it cannot repeat the effect or replace the prefix.

The module map is intentionally short:

| Module | Ownership |
| --- | --- |
| `PerryRuntimes.ExecutionPlan` | Canonical action order, action IDs, effect scopes, and approval digest. No journal copy of the plan. |
| `PerryGuide.WorkspaceActionJournal` | Prefix/current representation, strict codec, and plan/checkpoint validation. |
| `PerryGuide.TaskCoordinator` | Durable revisioned mutation, grant restoration, dispatch boundary, and report finalization. |
| `PerryGuide.ResumableTaskRunner` | One-action orchestration, nonterminal approval result, transcript retry, and partial stopped reporting. |
| `PerryRuntimes.WorkspaceFileRuntime` | Typed effect execution and receipt production; no replay policy. |
| `PerryCore.TranscriptStore` | Existing idempotent transcript persistence. |
| `App.AppController` | Chooses approval, one-action execution, retry/report, or cancellation from the typed progress and record projections. |
| `App.BackgroundTasksWindow` | Reads the current action and existing plan summaries; it does not interpret receipt authority. |

This keeps the first implementation serial and workspace-scoped. It does not remove Codex sandbox execution or invent receipt variants for adapters that have no grounded postcondition contract. Each later executor must supply its own typed receipt and validator before it enters the prefix.

## Migration rules

The current checkout writes store version 4 and accepts versions 1 through 4. This shape introduces version 5; the decoder accepts 1 through 5 and keeps unsupported stores untouched with writes blocked.

- Version 1 and 2 records decode as `TaskPlan.legacy(Plan)` with their raw steps and existing recovery behavior. No receipt or typed action is fabricated. A later successful save emits the v5 envelope with `planKind: "legacy"` and the same legacy flat fields.
- A v4 executable record with no journal becomes a v5 journal with an empty prefix and an awaiting current action at the checkpoint. This records the pending action without claiming that any effect happened.
- A v4 prepared or dispatched journal maps to the same current phase with an empty prefix. Its grant is restored only for a current record that still passes recovery, cancellation, and exact-plan validation.
- A v4 verified journal maps its receipt into the prefix and retains its attempt and grant IDs as evidence. If the verified action is followed by another plan action, the migration creates an awaiting current state for the next action. If the old record cannot prove a contiguous prefix, decoding rejects it and uses the existing quarantine or backup-recovery path rather than inventing missing receipts.
- v5 keeps `revision` as a UUID and generates a new UUID for every successful mutation. No revision counter is reset when a task ID is removed and re-enqueued.
- Legacy `start`, `beginRun`, `beginStep`, `approve`, `completeStep`, `checkpoint`, and related step methods continue to reject executable plans. Typed execution uses only the journal transitions, so one effect cannot be applied through both the legacy step path and the typed path.
- A backup can restore evidence and pause intent, but it never restores execution authority. A dispatched current action remains reconciliation-required after reload and cannot be replayed.

## Rationale

The receipt prefix matches the actual execution boundary: actions are ordered by the canonical plan, execution is serial, and only one grant-backed action can be prepared or dispatched at once. Appending a verified receipt and selecting the next current action is one durable mutation, which makes “A is done, B needs approval” a state the coordinator can validate without a second action map. Report-only recovery is equally explicit: a full prefix with `current == nil` contains evidence but no authority, so history can retry without running a worker.

The design follows boundary validation and type-driven state ownership. The journal accepts decoded data only after it has been compared with the plan and checkpoint; the coordinator is the only writer; the runtime only returns a receipt; and the runner does not convert an approval wait into a terminal `DoOutcome`. The public surface hides grant lifecycle, revision replacement, persistence ordering, and receipt validation behind the coordinator and runner methods, while callers retain only the decisions they actually own: show approval, continue one prepared action, or report a durable result.

## Synthesis decision

This is a candidate package for arena comparison. No synthesis decision or release gate completion is recorded here.

## Tradeoffs accepted

- We accept one extra journal-level plan digest and a validated checkpoint projection in exchange for rejecting mismatched persisted evidence before it can reach execution or UI approval.
- We accept a serial current-action boundary in exchange for a small authority surface and an unambiguous no-replay rule; parallel actions would need a different representation.
- We accept a version-5 migration branch in exchange for preserving v1/v2 legacy payloads and v4 typed approval, dispatch, and receipt evidence without a lossy `Step` facade.
- We accept report handling as a separate runner operation in exchange for retaining verified work when transcript persistence fails and avoiding worker recreation during retry.
- We accept receipt-prefix storage for the grounded workspace-file executor in exchange for waiting for real receipt contracts before adding generic adapter payloads.

## Alternatives considered

An ordered per-action journal would store one entry for every plan action, such as `pending`, `prepared`, `dispatched`, or `verified`, with the receipt on verified entries. It makes a future UI timeline easy to render and could support non-contiguous or parallel work, but its public access pattern exposes a collection that callers must scan and cross-check. The coordinator would need a second invariant saying that exactly one entry is mutable, that verified entries form a prefix, and that later entries cannot carry authority. For this serial runner, that repeats the prefix invariant while increasing persisted surface and malformed-state cases, so it has less interface depth than the prefix design.

A separate `completedReceipts` field on `TaskRecord` plus the existing optional `WorkspaceActionJournal` would minimize changes to the current enum, but it splits one action's evidence and current authority across two durable owners. Approval, reload, and report callers would have to combine fields before deciding whether dispatch is safe. It loses on locality and makes an interrupted mutation harder to validate atomically.

## Open questions and risks

- Should a cancelled partial report use the plan UUID as its stable transcript ID, or does the product need a separate stable report ID so a later user-visible retry can distinguish stopped and completed outcomes?
- Should a v4 verified record followed by additional actions be migrated automatically when its receipt proves action zero, or should that conversion wait for a store inspection that confirms the old runtime never executed a later action?
- Should the background UI display the number and paths of completed receipts, or is the current action plus plan summary enough for the first vertical slice?
- Which future executor owns the next typed receipt validator, and what exact postcondition makes that receipt safe to append to the common prefix?

## Next implementation step

Add strict v5 journal decoding and coordinator-owned prefix transitions, then cover the A-verified/B-awaiting, relaunch, uncertain-dispatch, partial-cancel, and failed-report traces through `TaskCoordinator` and `ResumableTaskRunner`.
