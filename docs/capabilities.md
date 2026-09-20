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

- Plans are typed and shown before execution. Dangerous or irreversible steps
  need an exact approval; writes to connected integrations need explicit
  enablement and per-write approval.
- You can pause, steer, retry, or stop any task; Perry verifies the end state
  and reports what it actually did.
- Limit: the bundled local planner handles a disclosed, deterministic task
  set only. Open-ended work requires a signed-in agent runtime (Claude Code /
  OpenCode / bundled Codex), which uses your own provider account and keys.

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
