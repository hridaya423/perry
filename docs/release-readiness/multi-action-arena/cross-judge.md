# Multi-action cross-judge

The completed-receipt prefix is the stronger M1 base because it makes the durable fact explicit: verified actions are a contiguous prefix and one current action is the only possible authority. It still needs a safety correction before adoption. The ordered journal is viable, but its entry array and separately written checkpoint projection expose more state than this serial workspace path needs.

## Scores

Scores are against the seven traces in [grounding.md](grounding.md), the current coordinator behavior, and the two candidate packages. They are design scores, not test evidence.

| Criterion | Ordered journal | Receipt prefix | Reason for the difference |
| --- | ---: | ---: | --- |
| Validated complete contiguous receipts | 4/5 | 5/5 | Both describe contiguous validation. The prefix makes the completed boundary structural and carries action index, action ID, and receipt together. |
| Approval, execution, final or partial reporting, and cancellation | 4/5 | 5/5 | Both separate prepared and dispatched authority from verified work. The prefix gives partial stopped reporting and the full-prefix report boundary a more explicit API. |
| v1–v4 preservation and no backup or uncertain-dispatch authority | 3/5 | 2/5 | Ordered journal preserves old values but leaves grant restoration implicit. Receipt prefix explicitly permits a dispatched grant to be restored into the authority registry. |
| Small coordinator-owned interface without duplicate state | 2/5 | 4/5 | Ordered journal writes an ordered journal and a checkpoint projection during migration. The prefix keeps one journal value and derives the compatibility projection. |
| Concrete seven recovery, approval, and test traces | 4/5 | 4/5 | Both name all seven required cases, but neither gives the exact persisted assertions for every duplicate, pause, backup, and report boundary. |
| Total | 17/25 | 20/25 | Receipt prefix is the better base only after the authority and evidence grafts below. |

## Authority and evidence review

The current safety boundary is narrow. `TaskCoordinator` restores only a prepared grant from a current, non-cancelled record at [TaskCoordinator.swift:401-405](../../../Packages/PerryGuide/Sources/PerryGuide/TaskCoordinator.swift#L401-L405), and `ExecutionApprovalRegistry` puts every restored grant into its authorizing map. A dispatched grant is after the effect boundary, so putting it back in that map would make replay possible even if the runner normally refuses reconciliation-required records.

That makes the sentence in [candidate-receipt-prefix.md](candidate-receipt-prefix.md) saying that a prepared or dispatched attempt may be restored into `ExecutionApprovalRegistry` a blocking flaw. Its later statement that dispatched work cannot be replayed contradicts the authority it restores. The required rule is: restore only the current prepared grant from a current record that passes exact plan, revision, cancellation, and lifecycle checks; restore no dispatched grant, no verified grant, and no grant from a backup-restored record. A dispatched record keeps its evidence and reconciliation state, never execution authority.

The two candidates also differ on completed approval evidence. The current verified journal retains the full `Attempt`, including its grant, alongside the receipt at [WorkspaceActionJournal.swift:33-35](../../../Packages/PerryGuide/Sources/PerryGuide/WorkspaceActionJournal.swift#L33-L35). Ordered journal therefore retains the evidence, but it must say explicitly that a grant inside a verified or dispatched entry is audit data and is never installed in the registry. Receipt prefix stores only `grantID` in `CompletedReceipt`. That preserves correlation, but loses the approval scope, task and plan binding, digest, and issue time carried by the v1–v4 grant. Its prefix should retain a non-authorizing approval-evidence value with those immutable fields, or retain the grant as evidence under a name and API that cannot be passed to registry restoration.

## Candidate assessment

Ordered journal has a sound state vocabulary. `awaitingApproval`, `prepared`, `dispatched`, and `verified` make the active tail visible, and preserving A while B is the tail is clear. Its cost is real: `entries` mixes completed prefix entries with an active tail, while the candidate also asks the coordinator to write and validate a `TaskCheckpoint` projection. That creates two durable representations of the cursor during the migration. A stale projection must never be selected as newer authority, and the candidate says that rule but does not reduce the opportunity for divergence. Its `requestWorkspaceActionApproval` transition is also needed at the initial queued record, whose current constructor still has no journal, so the runner usage needs one explicit initial materialization boundary.

Receipt prefix follows the actual serial executor more directly. `completed` is the durable receipt prefix, `current` is the single mutable authority, and the checkpoint projection can remain derived for compatibility. The coordinator and runner surfaces answer the caller's actual questions: approve the next action, dispatch one prepared action, execute it, or report a retained result. The prefix also makes a full report (`current == nil`) distinct from a partial stopped report. Its current grant-restoration sentence is a safety blocker, and its completed evidence is too thin for lossless v1–v4 preservation, but both are narrow grafts rather than a shape change.

## Recommendation and required grafts

Use [candidate-receipt-prefix.md](candidate-receipt-prefix.md) as the synthesis base, with these changes required before implementation:

1. Make `CurrentAction.prepared` the only reloadable execution authority. A `dispatched` current action is retained as uncertain and is never reinserted into `ExecutionApprovalRegistry`; a verified prefix and every backup-restored record are report or reconciliation data only.
2. Add immutable, non-authorizing approval evidence to each completed receipt. Preserve at least the grant ID, task ID, plan ID, plan digest, action scope, and issue time. Validate those fields against the plan and action, and enforce uniqueness across completed entries, the current attempt, and other persisted tasks.
3. Define the initial boundary from the existing `TaskRecord(executablePlan:)` shape: an unapproved queued record has no grant and no effect; the coordinator derives or persists an `awaitingApproval` current action before presenting approval. A successful A mutation creates the B-awaiting state without overwriting A.
4. Make report outcome legality coordinator-owned. A full prefix with no current action may produce completed history; a partial verified prefix may produce stopped history; a prepared current action may be cancelled without claiming an effect; a dispatched current action remains reconciliation-required. Callers must not supply an outcome that bypasses these checks.
5. Keep one mutable journal owner. Store the legacy `TaskCheckpoint` only as a derived envelope projection during v5 migration, validate it against `completed.count` and `current`, and never allow either caller or UI to mutate it independently.
6. Specify v1–v4 conversion per phase. Preserve old prepared and verified IDs and approval evidence; preserve dispatched evidence but do not restore its grant; never synthesize a receipt for a missing or inconsistent record; mark backup-restored records non-authorizing and paused. Unsupported primary or backup bytes remain untouched and writes stay blocked.
7. Turn the seven grounding traces into boundary tests with persisted assertions: A verified then B awaiting; relaunch between A and B; crash after B dispatch; cancellation after A; history failure after B; duplicate or stale approval, pause during issuance, and duplicate completion; and v1–v4 malformed, digest, order, checkpoint, and backup-authority rejection.

The ordered journal remains a reasonable alternative if a future consumer needs a complete per-action timeline or parallel entries. For the current serial runner, it should not be the base until it removes the duplicate mutable cursor and states the same prepared-only authority rule.

## Blocking flaws before synthesis

Receipt prefix cannot be accepted verbatim because dispatched grant restoration creates an execution-authority path through the existing registry. Ordered journal cannot be accepted verbatim because it leaves the distinction between retained grants and restored authority implicit while maintaining two cursor representations. Neither flaw requires a third candidate; the prefix shape plus the grafts above is the smallest synthesis that satisfies the current recovery contract.
