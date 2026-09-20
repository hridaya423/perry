# Multi-action journal grounding

This design extends the typed execution migration in M1 and durable task recovery in M3. It is not a replacement release scope. The first executable trace uses two UTF-8 file creations because that typed executor already exists; computer, integration, shell, and other transform adapters remain required by the release plan.

## Current path

`TaskRecord` in `TaskCoordinator.swift` owns a versioned plan, revision, lifecycle, checkpoint, intent, recovery disposition, and one optional `WorkspaceActionJournal`. Typed records use the same task envelope as legacy records; the writer emits version 4 and accepts versions 1–4. Unsupported versions remain untouched and block writes. Canonical plan bytes bind approvals and receipts.

`approveWorkspaceAction` issues an action-scoped grant, checks the record revision again after issuance, then persists a prepared journal and ready lifecycle. `beginWorkspaceDispatch` persists dispatch before execution. `executeWorkspaceAction` owns the cancellable child, records uncertainty before calling the executor, validates the receipt, advances the checkpoint, and revokes the grant. The journal's verified case retains the attempt and receipt, but approving another action would replace that journal.

The single-action restrictions are in `workspaceActionToApprove`, `canResumeWorkspaceTask`, and `ResumableTaskRunner.runWorkspaceTask`. The runner immediately reports after execution. Reporting writes history under the plan's stable UUID before removing the task. History failure retains the receipt; completed reporting can be retried without a workspace or Cua worker. Cancelled verified tasks can report but cannot execute another action.

The app's typed route chooses between execution and reporting by the current journal phase. Its approval sheet reads one `ExecutableAction` from a captured record and submits the captured revision. Capacity is three background runs. A ready record queues automatically; a paused failure requires explicit resumption. Legacy execution remains separate during migration.

`DoOutcome` currently has completed, blocked, and failed cases; it has no nonterminal approval-needed result. `TranscriptEntry.Outcome` separately has completed, stopped, and failed. A new multi-action runner must not encode an approval wait as task completion or discard partial verification when reporting cancellation. Account for the result contract explicitly rather than returning a synthetic completed outcome between actions.

## Required traces

1. Approve action A, persist dispatch, create and verify A, then stop at approval for B. No completion history or B effect may occur yet.
2. Relaunch between A and B. Retain A's receipt and request approval only for B. Approving B cannot discard A's evidence.
3. Crash after dispatching B but before its receipt is saved. Retain A's receipt and B's uncertain dispatch; do not replay either action.
4. Cancel after A. Record a stopped partial outcome with A's verified work represented; do not execute B or claim the plan completed.
5. Verify B, then fail the history write. Retain both receipts and retry reporting without any execution or workspace recreation.
6. Duplicate approval, stale revision, pause during approval issuance, and duplicate completion callback must not replace current authority or repeat effects.
7. Read old single-action envelopes without fabricating missing receipts. Reject inconsistent receipt order, action identity, plan digest, or checkpoint before restoring authority. A backup never grants execution authority.

## Design task

Produce a concrete type and interface sketch with caller examples, a module map, migration rules, and a rationale. Keep the coordinator as the owner of durable task mutation. Compare an ordered journal containing completed and current actions against a completed-receipt prefix plus one current action state. Explain how the chosen representation proves the checkpoint and makes report-only recovery distinct from execution. Keep effect dispatch below an already-persisted grant and intent boundary.

Use the architect runner prompt and rationale template. Do not add implementation comments or executable scaffolding. Write only the assigned candidate document; do not edit source. Source is authoritative if this grounding differs from the current checkout.

## Source locations

- `Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift`
- `Packages/PerryGuide/Sources/PerryGuide/WorkspaceActionJournal.swift`
- `Packages/PerryGuide/Sources/PerryGuide/ResumableTaskRunner.swift`
- `Packages/PerryRuntimes/Sources/PerryRuntimes/ExecutionPlan.swift`
- `Packages/PerryRuntimes/Sources/PerryRuntimes/WorkspaceFileRuntime.swift`
- `Packages/PerryCore/Sources/PerryCore/TranscriptStore.swift`
- `App/AppController.swift`: typed approval, execution, reporting, and cancellation paths
- `App/BackgroundTasksWindow.swift`: approval and resume controls
