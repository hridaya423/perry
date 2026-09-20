# Task backup recovery

Owner: Runtime/Execution. Scope: M3 recovery and M9 persistence. Environment: Apple Silicon macOS 26.5.1, development checkout. Evidence is deterministic testing, not release-proven durability.

## Reproduced failure

The task coordinator saves the previous primary as its backup before writing a new checkpoint. Corrupting the primary after beginStep restored the older backup without its in-flight marker. The recovered task became resumable and accepted resume, allowing a dispatched action to be repeated. The regression produced five failed assertions in /tmp/perry-backup-replay-before.log.

## Recovery contract

Every task restored from a backup is paused with a persisted restoredBackup disposition. The backup may predate dispatch, approval, cancellation, or completion, so its apparent checkpoint cannot authorize execution. The coordinator rejects start, resume, live resume, approval, dispatch, checkpoint completion, and successful task completion for those records. Cancellation and discard remain available. New tasks do not inherit the restriction.

The replacement primary contains the disposition, so another relaunch cannot clear it. If the primary is missing but a backup remains, loading restores the backup under the same restriction. The original backup and quarantined corrupt primary remain available for inspection.

Envelope version 2 requires an explicit recovery disposition. Version 1 accepts the older shape and writes version 2 on the next mutation. A malformed version-2 record cannot silently default to current. Exhausted checkpoints remain valid for finalization but cannot resume execution.

## Evidence and remaining work

The Guide package passed 107 tests with zero failures in /tmp/perry-backup-reviewed-guide.log. Recovery tests cover pre-dispatch backups, stale approval backups, every execution transition, a second relaunch, missing primary files, version migration, missing required disposition, safe discard, and exhausted checkpoints.

Independent review identified the exhausted-checkpoint entry paths and missing-primary recovery case. Both are covered by the current guards and tests; the reviewer confirmed the coordinator changes after those corrections. The review did not reproduce the tests from a clean checkout.

The final unsigned Debug app run passed 230 tests, skipped two live Cua tests, and had zero failures. Evidence: /tmp/perry-backup-reviewed-app.log and Test-Perry-2026.08.31_12-41-07-+0100.xcresult. No signed Release build or live recovery journey was run for this change.

## App integration

The task row now gives recovery notices precedence over stale approval controls. It explains that Perry cannot establish which action finished and asks the user to check the target app before creating new work. The warning text uses the primary foreground rather than orange text; the existing semantic warning icon provides an additional cue. Text can wrap without a line limit. An active task retains Stop; an inactive recovered task retains the existing confirmed deletion flow.

| Before | After | Why |
| --- | --- | --- |
| A restored approval appeared actionable | The row explains the uncertain result and omits Approve and Resume | An older approval must not authorize replay |
| Resume all included pending approvals | It selects resumable, inactive tasks without pending approval | A bulk resume is not an approval grant |
| Invalid launches reached capture setup | Cached and freshly loaded records pass the same launch policy first | Recovery and cancellation must stop setup as well as execution |

AppController checks BackgroundTaskLaunchGate.blocker before reserving a launch and again after loading the authoritative task record, before metadata lookup, capture, workspace lookup, and runtime selection. The coordinator remains the final execution authority. Live paused in-flight tasks retain their existing resume path; a restored-backup disposition takes precedence even over a stale live flag.

The unsigned Debug app suite passed 234 tests, skipped two live Cua tests, and had zero failures in Test-Perry-2026.08.31_12-47-00-+0100.xcresult. Log: /tmp/perry-recovery-ui-app.log. Four new tests exercise notice selection and launch-policy outcomes using real coordinator transitions and backup restoration. They do not instrument AppController's capture calls or operate notification buttons.

The interface has not yet passed live keyboard, VoiceOver, contrast, narrow-window, or increased-text inspection. Process-crash durability, disk-full recovery, real concurrent provider tasks, and clean-machine relaunch behavior also remain unproven. No M3 or M7 completion claim follows from this change.

The independent controller review found a missing lease check after the awaited runtime-route save. That check now prevents a cancelled setup from constructing and scheduling a runner after the save completes. The reviewer confirmed the corrected ordering. The unsigned Debug build and nine focused launch-gate/recovery tests passed in /tmp/perry-resumed-launch-check.log, with results in Test-Perry-2026.08.31_12-54-46-+0100.xcresult. Those tests cover lease invalidation and recovery policy, not an injected cancellation during the controller's save.
