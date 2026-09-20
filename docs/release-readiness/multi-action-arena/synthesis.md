# Multi-action execution contract

Use the receipt-prefix candidate, with full completed approval evidence and prepared-only authority restoration. The parent read both candidates completely and agrees with the independent comparison's choice: receipt prefix scored 20/25 and ordered journal 17/25. These scores compare designs, not release readiness. Neither candidate is accepted verbatim.

## Shape and ownership

`WorkspaceExecutionJournal` owns a completed prefix and one optional current attempt. Keep `WorkspaceActionJournal` as the existing single-action compatibility codec and validation boundary, rather than copying its grant and receipt validation. Its `Attempt` remains the evidence value used by both representations.

```swift
public struct WorkspaceExecutionJournal: Codable, Sendable {
    public struct CompletedAction: Codable, Sendable {
        public let attempt: WorkspaceActionJournal.Attempt
        public let receipt: WorkspaceFileExecutionReceipt
    }

    public enum CurrentAction: Codable, Sendable {
        case prepared(WorkspaceActionJournal.Attempt)
        case dispatched(WorkspaceActionJournal.Attempt)
    }

    public let completed: [CompletedAction]
    public let current: CurrentAction?
    public var checkpoint: TaskCheckpoint { get }
}
```

Construction and mutation stay inside PerryGuide; the app receives read-only state. An empty prefix with no current attempt means no action has been approved. A nonempty partial prefix with no current attempt means the next action needs approval. A full prefix with no current attempt means report-only work. These states are derived from the plan and journal; do not persist another action reference, journal-level plan digest, or approval-needed tail.

The validator proves that completed indexes are exactly `0..<completed.count`, that every attempt and receipt matches its plan action, and that a current attempt is at `completed.count`. It checks unique attempt and grant IDs within the journal; store validation also checks grant uniqueness across tasks. Existing per-action validation retains the grant scope, task and plan identities, digest, path bytes, and byte-count checks. Completed grants remain evidence and never enter the authorizing registry.

`TaskCoordinator` remains the sole durable writer. New records and successful mutations produce one atomic task envelope. The checkpoint for a typed record is derived from the journal; decoding compares the persisted compatibility checkpoint with that projection and rejects disagreement. Legacy records retain their current checkpoint behavior.

## Caller contract

One runner invocation executes at most one prepared action. It returns a distinct nonterminal result when another approval is needed:

```swift
public enum WorkspaceTaskProgress: Sendable {
    case awaitingApproval(TaskRecord)
    case reported(DoOutcome)
}
```

The app keeps task metadata after `.awaitingApproval`, releases the worker, and shows the next action from the refreshed record. It removes metadata only after confirmed reporting. It must not treat a successful function return as plan completion.

Reporting remains separate from execution and takes no runtime or workspace. The coordinator derives report legality: a full verified prefix with no current attempt is completed; cancellation with a partial prefix and no dispatched attempt is stopped. An unused prepared grant is revoked during cancellation and cannot authorize a later effect. A dispatched attempt or backup recovery blocks finalization for inspection. The caller cannot choose an outcome that overrides these rules. Stable transcript identity remains the plan UUID; retry updates the same report rather than duplicating it.

## Required transitions

| Event | Completed evidence | Current attempt | Result |
| --- | --- | --- | --- |
| Enqueue | empty | none | Approval required for A |
| Approve A | empty | prepared A | Ready for one execution |
| Persist dispatch | empty | dispatched A | Uncertain until receipt persists |
| Verify A | A retained | none | Approval required for B |
| Approve B | A retained | prepared B | Ready for one execution |
| Crash after dispatch B | A retained | dispatched B | Inspection required; no replay |
| Verify B | A and B retained | none | Report only |
| Cancel after A | A retained | none or revoked prepared B | Stopped partial report only |
| History write fails | unchanged | unchanged | Retain task for reporting retry |

Pause and cancellation intent survive every receipt append. Approval issuance rechecks cancellation and the exact record revision after its suspension point. Restoring grants from disk considers only a prepared current attempt in a current, non-cancelled primary record. Dispatched, completed, and backup-recovered attempts restore no execution authority.

## Migration and implementation order

The task envelope advances to version 5 when the coordinator adopts the new journal. Versions 1–2 remain legacy plans. Versions 3–4 decode their existing single-action journal and convert it without losing attempt, grant, receipt, revision, or intent. A prepared or dispatched old attempt at a later index cannot prove the missing prefix and is rejected for recovery inspection. A verified old action at index zero can become a one-entry prefix; it does not authorize a later action. A typed old record without a journal must still have an empty checkpoint. Unsupported versions stay untouched.

First implement the prefix value, strict codec, and conversion tests while keeping the production coordinator unchanged. Then migrate task-record encoding, transitions, grant restoration, and recovery to v5. Follow with the runner's nonterminal progress and partial-report handling, then the app's approval, queue, cancellation, and metadata paths. The slice is not complete until all those consumers use the new contract together.

The seven grounding traces require persisted assertions, not only in-memory state checks. Preserve existing single-action tests and add missing-prefix, duplicate-grant, out-of-order receipt, checkpoint mismatch, stale approval, partial cancellation, and failed-report coverage. Run package and app suites, independent critique, and clean-checkout reproduction before promoting the milestone. Real multi-action app interaction remains a separate live gate.

## Grafts and rejections

Retain the ordered candidate's full attempt and grant alongside every completed receipt. Adopt the prefix candidate's one-action runner result and separate partial reporting. Follow the cross-judge's prepared-only restoration and coordinator-owned report legality.

Reject the ordered array's mixed completed and mutable entries, its extra request-approval transition, and its one-case generic evidence wrapper. Reject the prefix candidate's dispatched-grant restoration and grant-ID-only completed evidence. Remove redundant journal plan identities and action references because the existing plan, attempts, and receipts already supply them. Do not add an event log or parallel-action scheduler for this serial boundary.

There were no candidate dropouts. The arena used the user-requested Luna agents, including the independent judge, rather than claiming a cross-model comparison.

## Verification status

Before the multi-action migration, a literal version-4 envelope fixture with two plan actions and one real verified receipt passed against the single-action reader (`/tmp/perry-v4-partial-fixture.log`). It preserved the original store bytes and left the second file absent. The unsigned Apple Silicon Release compilation also passed at that baseline (`/tmp/perry-current-release-build.log`); it does not establish signed distribution, live UI behavior, or any completed release gate.

The coordinator writes v5 envelopes and retains completed receipts while approving the next action. The runner and app distinguish awaiting approval from reporting, retain metadata between actions, and carry task revisions in approval notifications. The first complete Guide run passed 172 of 173 tests (`/tmp/perry-multi-action-guide-full-rerun-2.log`). `testPausedApprovalSurvivesRelaunchWithoutAutomaticRetry` caught dispatch clearing the saved pause intent before receipt persistence. Dispatch now preserves the paused state and pause intent together. The original assertion remains, with explicit state and intent checks added. Independent review found no source blocker, and the subsequent full Guide run passed all 173 tests, including all eleven prefix-codec tests (`/tmp/perry-multi-action-guide-full-rerun-3.log`).

All nine focused app lifecycle tests passed. They cover two separate approvals, retained metadata between actions, partial cancellation without recreating a moved workspace, and rejection of a notification whose cached revision no longer matches the authoritative task. The full app suite then passed 318 tests with two live-Cua tests skipped (`/tmp/perry-multi-action-full-app-verified.log`; Xcode result `Test-Perry-2026.08.31_21-07-39-+0100.xcresult`). This is an unsigned Debug run on macOS 26.5.1, arm64, from the dirty development checkout. It does not prove clean-checkout reproduction, live notification presentation, process-kill recovery, or M3 completion.

After the pause fix, the full app suite again passed 318 tests with two skipped and no failures (`/tmp/perry-multi-action-pause-app.log`; result `Test-Perry-2026.08.31_21-21-03-+0100.xcresult`). The unsigned Apple Silicon Release build also passed after the fix (`/tmp/perry-multi-action-pause-release.log`). Independent source review found no v5 journal-adoption integrity blocker. These results do not establish signing or release readiness.

An additional test persists a paused dispatched action, reloads it, rejects replay, and confirms that cancellation retains the uncertain journal across another reload without creating a file. The parent reviewed the test and ran the full Guide suite: all 174 tests passed (`/tmp/perry-paused-dispatch-guide-final.log`). This exercises disk reload through new coordinator instances, not an operating-system process kill.

The failing runs exposed an optional-enum ambiguity that retained pause intent during approval, a cancelled report that remained automatically runnable before explicit queuing, and a debug workspace root that ignored the isolated storage directory. These failures were fixed without weakening their assertions. Independent review also corrected legacy notification revision propagation and moved report-failure pausing into the runner's revision-bound reporting path. The app no longer pauses a newer task revision after an old worker fails.

Production task creation still has a blocking routing defect: `RuntimeRouteDecision.runtime` always returns `RuntimeProviderAdapter`, but `AppController.queueBackgroundTask` casts that adapter to `LocalTaskPlannerRuntime` before requesting a typed plan. The cast cannot succeed. The passing app tests seed typed records and do not exercise this entry point. Typed planning must travel through the selected provider's capability boundary, and the real queue-creation path needs its own regression test before this work can be called functional for users.

The separate local-planner follow-up rejects ambiguous unquoted contents and unsafe legacy canonical filenames while preserving typed filename whitespace. The runtime suite passed 195 tests with 10 live-provider tests skipped (`/tmp/perry-local-planner-runtime-followup.log`); the parent independently reran all eleven local-planner tests (`/tmp/perry-local-planner-parent-check.log`). This evidence does not promote the multi-action milestone.
