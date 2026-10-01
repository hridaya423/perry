# Workspace Undo — root-cause fix + live round-trip (2026-10-01)

Debug build post-fix, pid 61459. Task workspace
`~/PerryDemo/BackgroundTasks/ED89F016-1E75-473B-B9E7-99015E5220BB/`.

## Defect found by live drill

Undo on the completed `create file "bg-drill.txt"…` background task
dispatched a `moveToTrash` action that failed, parked the undo record
`paused` ("couldn't verify the last action… can't resume because
repeating it could change your work twice"), and reported the opaque
`(PerryRuntimes.ExecutionError error 1.)`.

Root cause, two layers:

1. **TCC**: `open()`/`openat()` on `~/.Trash` returns `EPERM` without
   Full Disk Access (verified with a standalone probe — `lstat` works,
   `open` does not). `WorkspaceFileRuntime` bound `~/.Trash` fine at
   init (`lstat`) but every trash/restore died in `openBoundDirectory`
   → `ExecutionError`. The fd-based design could never reach Finder
   Trash for a normal app.
2. **Error surfacing**: `ExecutionError`/`PlanError`/
   `CLIUnavailableError`/`ActionExecutionError` conformed to
   `CustomStringConvertible` but not `LocalizedError`, so
   `localizedDescription` dropped the message and showed `error 1`.

## Fix

- Default trash is now the workspace-local `.trash/` — the convention
  `FileTools.trash` already adopted (`FileTools.swift` comments note
  `trashItem` "blocks on Finder"). `WorkspaceFileRuntime`,
  `WorkspaceFileVerifier`, and `WorkspaceUndoEngine` defaults all point
  at `<workspace>/.trash`; created lazily at first trash so non-trash
  runs leave no empty directory. The atomic fd-based move
  (`renameatx_np` + `RENAME_EXCL` + identity/fsync verification) is
  unchanged — it was never the problem; its destination was.
- Trash entries use the FileTools naming `<epoch-ms>-<name>` with an
  `EEXIST` counter, so `.trash/` is human-readable.
- `LocalizedError` conformance added to the four error types; the
  runtime now surfaces e.g. "execution error: typed trash source
  identity does not match approval" instead of `error 1`.
- `inverseDescription` copy updated: "the workspace trash" — the old
  text claimed Finder Trash.

## Live verification

1. Undo on the completed create record → confirmation listed "Move the
   created file “bg-drill.txt” to the workspace trash" →
   `bg-drill.txt` moved to `.trash/1790834939741-bg-drill.txt`;
   undo record `09BFF478` completed with durable
   `trashed{device:16777234, inode:128880135}` receipt.
2. Undo on that completed undo record → "Restore “bg-drill.txt” from
   the workspace trash" → `restoreFromTrash` ran; `bg-drill.txt` is
   back at the workspace root with identical contents and the *same*
   inode 128880135 — identity held through the round trip; the `.trash`
   entry was consumed. Restore record `1B07F4E4` completed with a
   `restored` receipt.
3. The pre-fix failed undo record `5DBB8437` remains honestly `paused` —
   it cannot resume because its dispatched action is unverifiable; that
   protective posture is correct.

`tasks.json` receipts confirm all three legs durably journaled.

## Tests

- `testDefaultTrashLandsInWorkspaceTrashAndRestores` — default-bound
  runtime creates `.trash` lazily, trashes with identity, verifier
  accepts, restore round-trips bytes + inode.
- `testExecutionErrorSurfacesItsMessage` — pins the `localizedDescription`
  fix.
- Suites: PerryRuntimes 189 run / 0 fail (10 pre-existing skips),
  PerryGuide 268/268.
