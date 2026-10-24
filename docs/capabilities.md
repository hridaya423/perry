# What Perry can and can't do today

Public-beta contract, stated plainly. For the feature-level registry with
per-item evidence, see `docs/release-readiness/features.json`.

## Requirements

- macOS 14 or later, Apple Silicon.
- **Accessibility** and **Screen Recording** permissions for anything that
  touches the screen. Without them Perry runs but can't ground itself.
- The bundled Cua driver is required for grounded computer use. If it's
  unhealthy, Perry reports the failure — it never silently falls back to a
  second capture or action backend.

## Ask

- The default mode. Circle or point at anything on screen and ask about it —
  Perry grounds the answer in that window and region, and outlines the
  elements it means on screen.
- Follow-ups keep the session and re-look at the live screen; if the target
  window changed or closed, stale answers are refused rather than pointed at
  nothing.
- Ask never acts — a request that needs doing is routed to Do explicitly, it
  can't run while Ask is selected.
- Limit: without a configured provider, answers come from the visible labels
  and accessibility text on screen — literal, not inferential. With a
  provider, the bounded screen context for that question goes to that
  provider under your key; the active route is always shown.

## Guide

- Teaches in the app you're actually in: Perry reads the live screen, points
  at the real control, and advances only after your click or the expected
  screen change.
- Wrong clicks don't advance the lesson; on-screen controls let you re-point,
  skip, or stop.
- Limit: teaching quality depends on the target app exposing an accessibility
  tree. Apps with custom-drawn interfaces may be partially readable — file an
  app-compatibility report.

## Do

- Plans are typed and rehearsed before execution — the card previews every
  step with marks on the real targets. You can run, step through each action
  separately, repaint the preview, edit the goal, or stop.
- Dangerous or irreversible steps need an exact approval; writes to
  connected integrations need explicit enablement and per-write approval.
- You can pause, steer, take over, retry, or stop any task. Taking over
  hands you the pointer at a step boundary; continuing replans from the
  live screen rather than replaying what already succeeded.
- Perry verifies the end state and reports what it actually did — including
  partial results and the exact step that couldn't be done.
- Limit: the bundled local planner handles a disclosed, deterministic task
  set only. Open-ended work requires a conversation model: bundled Codex
  (ChatGPT sign-in), Claude Code (your Claude sign-in), your own API provider,
  or a local model. Claude Code runs with its built-in tools turned off and can
  use only the Perry tools of the current turn. ACP agents (Cursor, Gemini CLI,
  OpenCode, Goose, or any command) start in a read-only mode when they offer one,
  and Perry rejects their own requests to run commands or edit files. An ACP
  agent can still read files without asking.

## Undo

- Workspace file changes Perry made — creates, renames, trash moves — can be
  reversed from the tasks window. Each inverse action is itself approved,
  journaled, and verified.
- Undo stops at the first conflict: if you moved or edited a file since
  Perry touched it, that step and everything after it are left alone and
  the report says so.
- Limit: Undo covers file transforms only. GUI clicks, shell commands, and
  integration writes are reported honestly with no Undo — Perry refuses
  rather than guess. Removing a task's record removes its receipts, so its
  Undo goes with it.

## Routines

- Watch & Learn records a bounded demo you start and stop: Perry drafts a
  step list you review before it's saved — nothing saves silently, and the
  recorder captures steps and structure, not your keystrokes' values.
- Parameters marked "ask each run" prompt you each time; routines replay by
  re-reading the live screen, never by replaying coordinates.
- Limit: a renamed app or moved button may pause a run for input — that's
  the honest failure, not a bug. Routines are erased with everything else
  or on their own.

## Voice

- On-device dictation is the default. Push-to-talk is global. Optional
  realtime voice is BYOK behind disclosure — the active input route is always
  shown.
- Every voice failure path ends in a typed fallback; nothing you said is lost.
- Limit: dictation quality follows the system speech recognizer and your
  microphone. No always-listening beyond the remembered microphone mode you
  explicitly enable.

## Data

- Local-first. Requests, transcripts, and memory stay on this Mac; memory is
  plain Markdown you can inspect.
- History is searchable, exportable, and deletable per record. Settings →
  Memory & Privacy can erase everything.
- Screen pixels stay in memory; they're written only when you export them.
- No telemetry, analytics, or crash reporting of any kind.
- No in-app bug submission — diagnostics are exported by you and attached by
  hand (see `docs/support.md`).

## Distribution

- Updates via Sparkle only when a release build is configured with a valid
  signed feed; development builds never phone home.
- Beta builds are unsigned until Developer ID credentials are configured —
  install with right-click → Open. Signed/notarized releases come with the
  packaged beta.
