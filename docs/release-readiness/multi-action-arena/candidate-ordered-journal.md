# Ordered per-action journal candidate

## Usage (caller's view)

The caller asks the runner to advance a saved task and never edits journal state.

```swift
let progress = try await runner.runWorkspaceTask(
    record: record,
    runtime: runtime,
    history: transcriptStore,
    startedAt: startedAt
)
switch progress {
case .awaitingApproval(let actionID, let revision):
    presentApproval(taskID: record.id, actionID: actionID, revision: revision)
case .completed(let count):
    showFinished(count)
case .stopped(let count, let reason):
    showStopped(count, reason)
case .failed(let actionID, let reason):
    showFailure(actionID, reason)
}
```

The approval callback uses the revision returned with the request, then resumes the same boundary:

```swift
let approved = try await coordinator.approveWorkspaceAction(
    id: taskID,
    expectedRevision: revision
)
let progress = try await runner.runWorkspaceTask(
    record: approved,
    runtime: runtime,
    history: transcriptStore,
    startedAt: startedAt
)
```

After relaunch or a history-write failure, the caller selects report-only recovery from the saved record:

```swift
if record.canReportWithoutExecution {
    _ = try await runner.reportWorkspaceTask(
        record: record,
        history: transcriptStore,
        startedAt: startedAt
    )
}
```

## Problem

The typed route currently stores one optional journal, restricts approval and automatic resume to a one-action executable plan, and exposes only completed, blocked, or failed outcomes. The coordinator already separates persisted approval, dispatch, execution, receipt verification, cancellation, and report removal, but each transition replaces the one-action journal; the runner likewise reports the plan as one completed action. A multi-action route must retain A while B is awaiting approval or uncertain, without treating approval wait as completion or replaying an effect. This is the exact gap identified by the arena traces and current source: [grounding.md:7-15](grounding.md#L7-L15), [TaskCoordinator.swift:65-125](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L65-L125), [ResumableTaskRunner.swift:36-96](../../../Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift#L36-L96), [DoSupervisor.swift:33-37](../../../Packages/PerryRuntimes/Sources/PerryRuntimes/DoSupervisor.swift#L33-L37).

## Shape

`WorkspaceActionJournal` becomes one ordered value owned and mutated by `TaskCoordinator`:

```swift
struct WorkspaceActionJournal: Codable, Sendable {
    let entries: [Entry]
}

enum Entry: Codable, Sendable {
    case awaitingApproval(ActionRef)
    case prepared(Attempt)
    case dispatched(Attempt)
    case verified(Attempt, ActionEvidence)
}

struct ActionRef: Codable, Sendable {
    let actionIndex: Int
    let actionID: ActionID
}

enum ActionEvidence: Codable, Sendable {
    case workspaceFile(WorkspaceFileExecutionReceipt)
}
```

The array is contiguous in plan order and contains every completed entry. Only its last entry may be nonverified. `awaitingApproval` has an action identity but no grant or effect; `prepared` has a persisted grant but no dispatch; `dispatched` is uncertain and blocks automatic execution; `verified` carries the receipt that proves the action. A receipt case for each later adapter is added at that adapter's boundary; the first executable trace uses the existing workspace-file receipt, not a fabricated generic receipt ([ExecutionPlan.swift:16-54](../../../Packages/PerryRuntimes/Sources/PerryRuntimes/ExecutionPlan.swift#L16-L54), [WorkspaceFileRuntime.swift:112-145](../../../Packages/PerryRuntimes/Sources/PerryRuntimes/WorkspaceFileRuntime.swift#L112-L145)).

The journal validator enforces unique action IDs, contiguous indices, plan identity and digest, grant scope, receipt identity, and the prefix-plus-one-tail invariant. It derives `completedEntries`, `tail`, `nextAction`, and reportability. For executable records, `TaskCheckpoint` becomes a compatibility projection of this value; during migration the coordinator writes and validates both, but callers cannot use the projection to authorize execution. Legacy plans retain their existing checkpoint path.

The coordinator exposes transitions that each perform one persisted mutation:

```swift
func requestWorkspaceActionApproval(id: TaskID, expectedRevision: UUID) throws -> TaskRecord
func approveWorkspaceAction(id: TaskID, expectedRevision: UUID) async throws -> TaskRecord
func beginWorkspaceDispatch(id: TaskID, expectedRevision: UUID) throws -> TaskRecord
func executeWorkspaceAction(id: TaskID, expectedRevision: UUID, runtime: WorkspaceFileRuntime) async throws -> TaskRecord
func finishWorkspaceTask(id: TaskID, expectedRevision: UUID) throws -> DoOutcome
```

`requestWorkspaceActionApproval` appends the only permitted tail without an effect. Approval issuance rechecks revision and cancellation before converting that tail to `prepared`; dispatch converts it to `dispatched` before calling the runtime; successful execution converts it to `verified`. A verified tail is retained while the next action is requested. A dispatched tail remains retained after cancellation or crash, so neither it nor the verified prefix is replayed.

`ResumableTaskRunner` owns the use-case loop behind this boundary:

```swift
enum WorkspaceTaskProgress: Equatable, Sendable {
    case completed(stepsRun: Int)
    case awaitingApproval(actionID: ActionID, revision: UUID)
    case stopped(verifiedSteps: Int, reason: String)
    case failed(actionID: ActionID, reason: String)
}

func runWorkspaceTask(...) async throws -> WorkspaceTaskProgress
func reportWorkspaceTask(...) async throws -> WorkspaceTaskProgress
```

The runner continues through actions already covered by a valid persisted authority, returns `.awaitingApproval` when the next action needs a new approval, and never turns that state into `.completed`. Reporting reads verified entries, appends one transcript entry, and removes the task only after the history write succeeds. `TranscriptStore.append` already replaces an entry with the same ID before persisting, which supplies the report retry boundary ([TranscriptStore.swift:55-86](../../../Packages/PerryCore/Sources/PerryCore/TranscriptStore.swift#L55-L86)).

## Module map

- `PerryRuntimes/ExecutionPlan.swift` remains the immutable source of action order, unique IDs, approval scope, idempotency policy, and canonical digest ([ExecutionPlan.swift:16-54](../../../Packages/PerryRuntimes/Sources/PerryRuntimes/ExecutionPlan.swift#L16-L54)).
- `PerryGuide/WorkspaceActionJournal.swift` owns the persisted entry state machine and strict validation; it performs no process or workspace IO ([WorkspaceActionJournal.swift:33-137](../../../Packages/PerryGuide/Sources/PerryGuide/WorkspaceActionJournal.swift#L33-L137)).
- `PerryGuide/TaskCoordinator.swift` owns record revisions, journal mutation, approval grants, dispatch intent, cancellation, persistence, and the no-replay decision ([TaskCoordinator.swift:447-545](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L447-L545)).
- `PerryGuide/ResumableTaskRunner.swift` owns action sequencing and report-only recovery; it does not construct or mutate journal storage ([ResumableTaskRunner.swift:36-96](../../../Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift#L36-L96)).
- `App/AppController.swift` remains a caller: route approval, run, cancellation, ownership waiting, and report retry through the runner/coordinator. Its current cancellation and workspace-run paths are the migration seams ([AppController.swift:1606-1690](../../../App/AppController.swift#L1606-L1690), [AppController.swift:1862-1925](../../../App/AppController.swift#L1862-L1925)).
- `App/BackgroundTasksWindow.swift` renders the journal-derived next action and approval state; it must not infer completion from a checkpoint alone ([BackgroundTasksWindow.swift:136-150](../../../App/BackgroundTasksWindow.swift#L136-L150)).

## Migration rules

1. Bump the persisted task envelope from version 4 to the next schema version. Decode versions 1–4; for v3–v4 executable records, wrap the existing single journal as one ordered entry while preserving its attempt ID, grant, phase, revision, and receipt. Keep v1–v2 legacy decoding as it works today, including their generated revision, never synthesize a missing receipt, and keep a dispatched entry uncertain. Unsupported versions remain untouched and block writes ([TaskCoordinator.swift:183-190](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L183-L190), [TaskCoordinator.swift:1222-1250](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L1222-L1250)).
2. Keep `TaskPlan.legacy` and its runner path unchanged. For executable records, normalize the old singular journal at the coordinator boundary, derive the checkpoint projection from the ordered journal, and reject any mismatch rather than selecting whichever representation looks newer.
3. Replace the current one-action guards with “next contiguous action” validation. Approval for B appends after verified A; it never replaces A. Duplicate approval, stale revision, pause during issuance, and duplicate completion must be idempotent or rejected without replacing the current tail.
4. Keep effect dispatch below a persisted prepared grant and dispatch record. A failed or cancelled dispatch retains the tail and blocks replay; cancellation after verified A records a stopped partial result and cannot claim the plan completed. These are required traces, not release conclusions ([grounding.md:19-25](grounding.md#L19-L25)).
5. On report failure, retain every verified entry and retry through `reportWorkspaceTask` without recreating workspace, Cua, or an executor. Remove the task only after the transcript append and task removal both have an explicit successful boundary; an uncertain tail never becomes a verified step ([TaskCoordinator.swift:558-571](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L558-L571)).
6. Add the journal behind the existing typed route first with two workspace-file actions. Preserve the existing proof that approval survives relaunch, dispatch uncertainty blocks replay, duplicate dispatch has one effect, and completion requires the current verified receipt ([WorkspaceActionJournalTests.swift:20-55](../../../Packages/PerryGuide/Tests/PerryGuideTests/WorkspaceActionJournalTests.swift#L20-L55), [WorkspaceActionJournalTests.swift:101-180](../../../Packages/PerryGuide/Tests/PerryGuideTests/WorkspaceActionJournalTests.swift#L101-L180), [WorkspaceActionJournalTests.swift:217-238](../../../Packages/PerryGuide/Tests/PerryGuideTests/WorkspaceActionJournalTests.swift#L217-L238)).

## Constraints

### Preserve

- Preserve plan digest and action identity checks, persisted approval before dispatch, uncertain-dispatch retention, report-only retry, cancellation intent, and the unchanged legacy route.

### Change

- Change only executable task storage and orchestration from one action to an ordered journal, and add an explicit approval-needed progress result so B cannot be reported as completed.

### Avoid

- Avoid replay after an uncertain tail, silent receipt fabrication, journal mutation in UI or runtimes, an event-sourced projection, or a generic receipt blob before an adapter requires it.

### Risk

- Risk remains around plan-scoped grant lifetime, adapter-specific receipt schemas, version-4 backup normalization, and the user-facing treatment of a stopped task with an uncertain tail.

## Evidence boundary

Direct evidence is the current singular journal, one-action guards, persisted phase ordering, report-after-verified behavior, and the existing tests cited above. The ordered array, approval-needed result, checkpoint projection, and schema migration are design proposals derived from those constraints and the required traces; the repository does not document them as historical decisions. The first file-creation trace is executable grounding, while computer, integration, shell, and other transform adapters remain outside this candidate's verified implementation surface ([grounding.md:3](grounding.md#L3)).

## Rationale

The ordered array makes the durable fact a single sequence: verified entries form a prefix and the final entry is the only possible authority in transition. That lets one validator prove action order, preserve A while B is prepared or uncertain, and let reporting consume the same retained receipts. It hides persistence, grant, and recovery mechanics behind the coordinator and runner, leaving callers with one progress result rather than a stage protocol.

### Tradeoffs accepted

- We accept custom Codable and a schema migration in exchange for one serialized ordering invariant.
- We accept retaining grants, attempts, and receipts for every completed action in exchange for report-only recovery and a durable action sequence.
- We accept one nonverified tail blocking later execution in exchange for never replaying an uncertain effect.
- We accept a temporary derived checkpoint during migration in exchange for keeping current UI and legacy records readable; only the journal may authorize executable work.

### Alternatives considered

The completed-prefix alternative stores `verifiedEntries` plus one separate `currentAction` state. It is smaller and makes the common prefix explicit, but recovery, reporting, and UI must coordinate two representations and merge the current state at every promotion. It hides less of the ordering rule behind one validator, so it loses on interface depth even though its local transition code is simpler.

An append-only event log would preserve the richest history, but it adds replay, projection, duplicate-event handling, and another schema without a current consumer that needs event-level history. It loses on evidence-driven complexity and is rejected for this migration.

## Open questions and risks

- Should a plan-scoped approval be retained and referenced by later entries, or should the coordinator issue one grant per action before each dispatch?
- What typed receipt cases will the computer, integration, shell, and remaining transform adapters add before they migrate into this journal?
- Should a stopped task with an uncertain tail report only verified actions, or also surface a separate reconciliation notice without implying that the tail ran?
- Can version-4 backups be normalized with the same rule as primary records, including a dispatched single-action journal?

## Synthesis decision

Pending arena synthesis. This is a design candidate only; no release gate is marked complete.

## Next implementation step

Add pure journal validation and migration tests for the seven required traces before changing the application route; no production implementation is implied by this candidate.
