# Background tasks — live drill (2026-10-01)

Debug build, pid 61459/6859. Workspace `~/PerryDemo/BackgroundTasks/`.
Companion doc: `workspace-undo.md` (the Undo legs).

## Drive

1. Status item → "Run in background…" → alert with task field, runtime
   picker, and Queue button.
2. Goal: `create file "bg-drill.txt" with "hello from background"`.

## Runtime selection

- Picker offered **Automatic** and **Perry local planner** (plus
  unavailable runtimes). First attempt on Automatic produced no record —
  the router had nothing suitable; honest no-op, no phantom task.
- Re-queued with **Perry local planner** — deterministic typed plan:
  `createUTF8File(path: "bg-drill.txt")`, `approvalRequirement: action`,
  `requestedScopes: workspaceWrite`, file-contents postcondition.
- Task record `ED89F016-1E75-473B-B9E7-99015E5220BB` appeared in the
  Background Tasks window as **Queued · step 1 of 1** — "Review the file
  and approve its creation before running."

## Plan review + execution

- "Review file" → detail showing the planned path and contents →
  Approve → typed workspace runtime created and verified the file.
- Record flipped to **Completed**; `tasks.json` holds a durable
  `createdFile{path, byteCount:21}` receipt.
- On disk: `bg-drill.txt` with exact bytes `hello from background`.

## Verified

- Runtime selection is a real user choice with honest behavior on
  Automatic (no suitable runtime → nothing queued).
- The local planner emits a typed, approvable plan; approval gates
  execution; the journal records a durable receipt that Undo can read.
- Notification of completion surfaces in the record itself (the row
  shows Completed); system-banner delivery needs user-granted
  notification permission and is not claimed.
